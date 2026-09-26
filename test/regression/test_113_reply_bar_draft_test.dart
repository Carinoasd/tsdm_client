import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart' show BBCodeExt;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// GitHub #117: a notification tap or the home button closes the pages above the notice page, but never one where a
/// reply is being written. The reply bar tells its page's route about the reply ([RouteDrafts]); the navigation side is
/// covered in test_113_notification_navigation_test.dart.

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

const _parameters = ReplyParameters(fid: '2', tid: '3', postTime: null, formHash: 'XXXXXXXX', subject: 'subject');

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

  /// A thread page with a reply bar, returns the controller and the route of the page.
  Future<(ReplyBarController, Route<dynamic>)> pumpPage(WidgetTester tester, {bool closed = false}) async {
    final controller = ReplyBarController();
    final auth = AuthenticationRepository(user: _alice);
    final bloc = ReplyBloc(replyRepository: const ReplyRepository())
      ..add(const ReplyParametersUpdated(_parameters))
      ..add(ReplyThreadClosed(closed: closed));
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
    return (controller, ModalRoute.of(tester.element(find.text('thread page')))!);
  }

  testWidgets('an open editor and an unsent reply are drafts of the page, a sent or empty one is not', (tester) async {
    final (controller, route) = await pumpPage(tester);
    expect(RouteDrafts.hasDraft(route), isFalse, reason: 'nothing written yet');

    controller.setHintText('reply');
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);
    expect(RouteDrafts.hasDraft(route), isTrue, reason: 'the user is writing, even before the first letter');

    // Close without writing: nothing to keep.
    controller.closeEditor();
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isFalse);
    expect(RouteDrafts.hasDraft(route), isFalse);

    // Write, close without sending: the reply waits in the collapsed box.
    controller.setHintText('reply');
    await tester.pumpAndSettle();
    tester.widget<RichEditor>(find.byType(RichEditor)).controller.insertBBCode('hello');
    await tester.pumpAndSettle();
    controller.closeEditor();
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isFalse);
    expect(find.textContaining('hello'), findsOneWidget, reason: 'the collapsed box keeps the unsent reply');
    expect(RouteDrafts.hasDraft(route), isTrue);
  });

  testWidgets('the hint of a closed thread is not a draft', (tester) async {
    final (_, route) = await pumpPage(tester, closed: true);
    expect(RouteDrafts.hasDraft(route), isFalse);
  });

  testWidgets('the page forgets its draft once the bar is gone', (tester) async {
    final (controller, route) = await pumpPage(tester);
    controller.setHintText('reply');
    await tester.pumpAndSettle();
    expect(RouteDrafts.hasDraft(route), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();
    expect(RouteDrafts.hasDraft(route), isFalse);
    expect(tester.takeException(), isNull);
  });
}
