import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Issue #18: on desktop, Ctrl+Enter and Alt+Enter in the expanded reply editor send the reply, exactly when the send
/// button would; plain Enter keeps its meaning and an empty editor sends nothing.

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

const _parameters = ReplyParameters(fid: '2', tid: '3', postTime: null, formHash: 'XXXXXXXX', subject: 'subject');

/// Records the send requests the bar issues instead of forwarding them, so nothing touches the network; every other
/// event (reply parameters, closed state) reaches the real bloc.
final class _RecordingReplyBloc extends ReplyBloc {
  _RecordingReplyBloc() : super(replyRepository: const ReplyRepository());

  final sent = <ReplyToThreadRequested>[];

  @override
  void add(ReplyEvent event) {
    if (event is ReplyToThreadRequested) {
      sent.add(event);
      return;
    }
    super.add(event);
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// A thread page with an open thread, a logged in user and the expanded editor showing.
  Future<(ReplyBarController, _RecordingReplyBloc)> pumpEditor(WidgetTester tester) async {
    final controller = ReplyBarController();
    final auth = AuthenticationRepository(user: _alice);
    final bloc = _RecordingReplyBloc()
      ..add(const ReplyParametersUpdated(_parameters))
      ..add(const ReplyThreadClosed(closed: false));
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
    controller.setHintText('reply');
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);
    expect(find.byType(RichEditor), findsOneWidget);
    return (controller, bloc);
  }

  /// Type into the expanded editor and make sure it owns the keyboard focus.
  Future<void> typeAndFocus(WidgetTester tester, String text) async {
    final editor = tester.widget<RichEditor>(find.byType(RichEditor));
    editor.controller.insertBBCode(text);
    editor.editorFocusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(editor.editorFocusNode!.hasFocus, isTrue, reason: 'the shortcut only fires while the editor has focus');
    expect(editor.controller.isEmpty, isFalse);
  }

  Future<void> pressEnterWith(
    WidgetTester tester,
    List<LogicalKeyboardKey> modifiers, {
    LogicalKeyboardKey? key,
  }) async {
    for (final m in modifiers) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyEvent(key ?? LogicalKeyboardKey.enter);
    for (final m in modifiers.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pumpAndSettle();
  }

  FilledButton sendButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(FilledButton)));

  setUpAll(() {
    // The shortcut is a desktop feature; these tests run on the Linux host.
    expect(isDesktop, isTrue, reason: 'the shortcut tests need a desktop host');
  });

  testWidgets('Ctrl+Enter and Alt+Enter send the reply, plain Enter does not', (tester) async {
    final (_, bloc) = await pumpEditor(tester);
    await typeAndFocus(tester, 'hello');
    expect(sendButton(tester).onPressed, isNotNull, reason: 'the button is enabled, so is the shortcut');

    await pressEnterWith(tester, [LogicalKeyboardKey.controlLeft]);
    expect(bloc.sent, hasLength(1));
    expect(bloc.sent.single.replyParameters, _parameters);
    expect(bloc.sent.single.replyMessage, contains('hello'));

    await pressEnterWith(tester, [LogicalKeyboardKey.altLeft]);
    expect(bloc.sent, hasLength(2));

    await pressEnterWith(tester, [LogicalKeyboardKey.controlLeft], key: LogicalKeyboardKey.numpadEnter);
    expect(bloc.sent, hasLength(3), reason: 'the numpad Enter counts too');

    await pressEnterWith(tester, []);
    expect(bloc.sent, hasLength(3), reason: 'plain Enter is a newline, not a send');

    await pressEnterWith(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft]);
    expect(bloc.sent, hasLength(3), reason: 'only the exact combinations send');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shortcut does nothing while the send button is disabled', (tester) async {
    final (_, bloc) = await pumpEditor(tester);
    final editor = tester.widget<RichEditor>(find.byType(RichEditor));
    editor.editorFocusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(editor.controller.isEmpty, isTrue);
    expect(sendButton(tester).onPressed, isNull, reason: 'nothing to send');

    await pressEnterWith(tester, [LogicalKeyboardKey.controlLeft]);
    await pressEnterWith(tester, [LogicalKeyboardKey.altLeft]);
    expect(bloc.sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shortcut is not seen while the editor does not have the focus', (tester) async {
    final (_, bloc) = await pumpEditor(tester);
    await typeAndFocus(tester, 'hello');
    // Move the focus away from the editor, to the page itself.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await pressEnterWith(tester, [LogicalKeyboardKey.controlLeft]);
    expect(bloc.sent, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
