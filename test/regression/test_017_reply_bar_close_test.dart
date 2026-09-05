import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// A page like the thread page: the reply bar sits at the bottom and disappears while the thread reloads.
class _Host extends StatefulWidget {
  const _Host(this.controller, {super.key});

  final ReplyBarController controller;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool showBar = true;

  /// The thread reload emptied the post list: rebuild without the reply bar.
  void hideBar() => setState(() => showBar = false);

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

  Future<(ReplyBarController, GlobalKey<_HostState>)> pumpPage(WidgetTester tester) async {
    final controller = ReplyBarController();
    final key = GlobalKey<_HostState>();
    final auth = AuthenticationRepository();
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
              initialRoute: '/thread',
              routes: {
                '/': (_) => const Scaffold(body: Center(child: Text('forum page'))),
                '/thread': (_) => _Host(controller, key: key),
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('thread page'), findsOneWidget);
    return (controller, key);
  }

  Future<void> openEditor(WidgetTester tester, ReplyBarController controller) async {
    controller.setHintText('reply');
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);
    expect(find.byIcon(Icons.unfold_less), findsOneWidget, reason: 'the expanded editor is showing');
  }

  Future<void> reloadWithoutBar(WidgetTester tester, GlobalKey<_HostState> key) async {
    // The thread reload empties the post list, the page rebuilds without the reply bar and the bar is disposed.
    key.currentState!.hideBar();
    await tester.pumpAndSettle();
  }

  testWidgets('closing the editor through the controller and reloading keeps the thread page', (tester) async {
    final (controller, key) = await pumpPage(tester);
    await openEditor(tester, controller);

    controller.closeEditor();
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isFalse);
    expect(find.byIcon(Icons.unfold_less), findsNothing);

    await reloadWithoutBar(tester, key);
    expect(find.text('thread page'), findsOneWidget, reason: 'the page must not be popped by the bar dispose');
    expect(find.text('forum page'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the editor through the navigator and reloading keeps the thread page', (tester) async {
    final (controller, key) = await pumpPage(tester);
    await openEditor(tester, controller);

    // What the thread page used to do on a successful reply.
    Navigator.of(tester.element(find.text('thread page'))).pop();
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isFalse);
    expect(find.text('thread page'), findsOneWidget, reason: 'the pop only closed the sheet');

    await reloadWithoutBar(tester, key);
    expect(find.text('thread page'), findsOneWidget, reason: 'the bar dispose must not pop a second time');
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the bar while the editor is open closes the editor and keeps the page', (tester) async {
    final (controller, key) = await pumpPage(tester);
    await openEditor(tester, controller);

    await reloadWithoutBar(tester, key);
    expect(controller.showingEditor, isFalse);
    expect(find.byIcon(Icons.unfold_less), findsNothing);
    expect(find.text('thread page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closeEditor is a no-op when nothing is showing', (tester) async {
    final (controller, _) = await pumpPage(tester);
    controller
      ..closeEditor()
      ..closeEditor()
      ..dispose();
    await tester.pumpAndSettle();
    expect(find.text('thread page'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
